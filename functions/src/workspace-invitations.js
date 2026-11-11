'use strict';
const {activeMembershipGeneration} = require('./membership-generation');
const {mutationEpisode} = require('./mutation-episode');
const {removedStaff, applyStaffRejoin} = require('./membership-rejoin');

const {randomBytes, createHash, timingSafeEqual} = require('node:crypto');
class InvitationError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = (code, message) => { throw new InvitationError(code, message); };
const hash = (s) => createHash('sha256').update(s).digest('hex');
const id = (s) => typeof s === 'string' && s.length > 0 && s.length <= 128 &&
  s.trim() === s && !/[\/\p{Cc}]/u.test(s) && !['.', '..'].includes(s);
const email = (s) => {
  if (typeof s !== 'string' || s.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim())) {
    fail('invalid-argument', 'A valid email address is required.');
  }
  return s.trim().toLowerCase();
};
const active = (d, uid, cafeId) => d && d.uid === uid && d.cafeId === cafeId &&
  d.status === 'active' && d.schemaVersion === 1;
function input(data, fields) {
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      Object.keys(data).some((key) => !fields.includes(key))) fail('invalid-argument', 'Invalid invitation request.');
}
function actor(auth) {
  if (!id(auth?.uid)) fail('unauthenticated', 'Sign in to continue.');
  return auth.uid;
}
async function owner(tx, uid) {
  const map = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = map?.cafeId;
  if (!id(cafeId) || !active(map, uid, cafeId)) fail('permission-denied', 'Verified workspace owner required.');
  const cafe = await tx.get(`cafes/${cafeId}`);
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const generation = activeMembershipGeneration(map, member, uid, cafeId, uid);
  if (cafe?.ownerUid !== uid || cafe.status !== 'active' || cafe.schemaVersion !== 1 ||
      !active(member, uid, cafeId) || member.role !== 'owner' ||
      generation === null) {
    fail('permission-denied', 'Verified workspace owner required.');
  }
  return {cafeId, generation};
}
function requestId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{16,64}$/.test(value)) {
    fail('invalid-argument', 'Invalid invitation request ID.');
  }
  return value;
}
const millis = (value) => value instanceof Date ? value.getTime() : value?.toMillis?.();
function expectedOwner(episode, authority) {
  if (episode.expectedCafeId !== authority.cafeId || episode.expectedMembershipGeneration !== authority.generation) {
    fail('failed-precondition', 'Workspace membership changed. Reopen invitations before trying again.');
  }
}

async function createStaffInvitation({auth, data, store, now = () => new Date(),
  toTimestamp = (d) => d, random = randomBytes, allowRejoin = false, resolveAccount}) {
  const uid = actor(auth);
  const {episode, payload} = mutationEpisode(data, InvitationError);
  input(payload, ['email', 'requestId']);
  const targetEmail = email(payload.email); const request = requestId(payload.requestId);
  // Internal dependency only, never accepted in request data. Existing callable
  // wiring supplies neither option, so rejoin issuance remains disabled.
  let target;
  if (allowRejoin === true) {
    if (typeof resolveAccount !== 'function') fail('failed-precondition', 'Rejoin account lookup unavailable.');
    target = await resolveAccount(targetEmail);
    if (target && (!id(target.uid) || target.disabled || !target.emailVerified || email(target.email) !== targetEmail)) {
      fail('failed-precondition', 'Invitation target could not be verified.');
    }
  }
  const invitationId = random(16).toString('hex');
  const secret = random(32).toString('hex');
  const code = `${invitationId}.${secret}`;
  const time = now(); const expires = new Date(time.getTime() + 24 * 60 * 60 * 1000);
  await store.runTransaction(async (tx) => {
    const authority = await owner(tx, uid);
    expectedOwner(episode, authority);
    const {cafeId, generation} = authority;
    let binding = {};
    if (target) {
      const mapping = await tx.get(`user_cafe_memberships/${target.uid}`);
      if (mapping) {
        const old = await removedStaff(tx, target.uid, fail);
        binding = {bindingVersion: 1, targetUid: target.uid,
          targetGeneration: old.mapping.membershipGeneration,
          previousCafeId: old.mapping.cafeId, removalEventId: old.mapping.removalEventId};
      }
    }
    const receipt = `workspace_invite_requests/${hash(`${uid}\0${request}`)}`;
    const ratePath = `workspace_invite_limits/${hash(`${uid}\0create\0${Math.floor(time.getTime() / 3600000)}`)}`;
    const previous = await tx.get(receipt); const rate = await tx.get(ratePath);
    if (previous) fail('already-exists', 'Invitation request already used. Revoke and create a new invitation if needed.');
    if (rate && (!Number.isSafeInteger(rate.count) || rate.count < 0 || rate.count >= 10)) {
      fail('resource-exhausted', 'Invitation limit reached. Try later.');
    }
    const invitePath = `workspace_invitations/${invitationId}`;
    if (await tx.get(invitePath)) fail('unavailable', 'Please create a new invitation request.');
    tx.create(invitePath, {cafeId, ownerUid: uid, email: targetEmail, role: 'staff',
      issuerBindingVersion: 1, issuerMembershipGeneration: generation,
      tokenHash: hash(code), status: 'pending', schemaVersion: 1,
      createdAt: toTimestamp(time), expiresAt: toTimestamp(expires), ...binding});
    tx.create(receipt, {uid, cafeId, invitationId, createdAt: toTimestamp(time)});
    const counter = {count: (rate?.count ?? 0) + 1, updatedAt: toTimestamp(time)};
    if (rate) tx.update(ratePath, counter); else tx.create(ratePath, counter);
  });
  return {invitationId, code, expiresAt: expires.toISOString()};
}
async function revokeStaffInvitation({auth, data, store, now = () => new Date(), toTimestamp = (d) => d}) {
  const uid = actor(auth);
  const {episode, payload} = mutationEpisode(data, InvitationError);
  input(payload, ['invitationId']);
  if (!/^[a-f0-9]{32}$/.test(payload.invitationId ?? '')) fail('invalid-argument', 'Invalid invitation ID.');
  await store.runTransaction(async (tx) => {
    // Current Owner authority may revoke stale or legacy invitations for cleanup.
    const authority = await owner(tx, uid);
    expectedOwner(episode, authority);
    const {cafeId} = authority;
    const path = `workspace_invitations/${payload.invitationId}`;
    const invite = await tx.get(path);
    if (!invite || invite.cafeId !== cafeId || invite.ownerUid !== uid || invite.schemaVersion !== 1) {
      fail('permission-denied', 'Invitation is unavailable.');
    }
    if (invite.status === 'revoked') return;
    if (invite.status !== 'pending') fail('failed-precondition', 'Invitation is already used.');
    tx.update(path, {status: 'revoked', revokedAt: toTimestamp(now()), revokedBy: uid});
  });
  return {revoked: true};
}
async function redeemStaffInvitation({auth, data, store, now = () => new Date(), toTimestamp = (d) => d, allowRejoin = false}) {
  const uid = actor(auth); input(data, ['code']);
  if (auth.token?.email_verified !== true) fail('failed-precondition', 'Verify your email and sign in again before joining.');
  const address = email(auth.token.email);
  if (typeof data.code !== 'string' || !/^[a-f0-9]{32}\.[a-f0-9]{64}$/.test(data.code)) {
    fail('invalid-argument', 'Invalid invitation code.');
  }
  const time = now();
  // Separate admission transaction counts failed redemption attempts too.
  await store.runTransaction(async (tx) => {
    const path = `workspace_invite_limits/${hash(`${uid}\0redeem\0${Math.floor(time.getTime() / 600000)}`)}`;
    const rate = await tx.get(path);
    if (rate && (!Number.isSafeInteger(rate.count) || rate.count < 0 || rate.count >= 10)) fail('resource-exhausted', 'Too many attempts. Try later.');
    const counter = {count: (rate?.count ?? 0) + 1, updatedAt: toTimestamp(time)};
    if (rate) tx.update(path, counter); else tx.create(path, counter);
  });
  const invitationId = data.code.split('.')[0];
  return store.runTransaction(async (tx) => {
    const path = `workspace_invitations/${invitationId}`;
    const invite = await tx.get(path);
    const digest = invite?.tokenHash;
    if (!invite || invite.schemaVersion !== 1 || !id(invite.ownerUid) || !id(invite.cafeId) ||
        invite.role !== 'staff' || typeof digest !== 'string' || !/^[a-f0-9]{64}$/.test(digest) ||
        !timingSafeEqual(Buffer.from(digest, 'hex'), Buffer.from(hash(data.code), 'hex')) || invite.email !== address) {
      fail('permission-denied', 'Invitation is invalid or not available for this account.');
    }
    if (invite.status !== 'pending') fail('failed-precondition', 'Invitation is revoked or already used.');
    const expiry = millis(invite.expiresAt);
    if (!Number.isFinite(expiry) || expiry <= now().getTime()) fail('failed-precondition', 'Invitation has expired.');
    // Issuer binding is independent of the optional Staff rejoin target binding.
    // Missing bindings never inherit the current Owner generation, even zero.
    if (!Object.hasOwn(invite, 'issuerBindingVersion') || invite.issuerBindingVersion !== 1 ||
        !Object.hasOwn(invite, 'issuerMembershipGeneration') ||
        !Number.isSafeInteger(invite.issuerMembershipGeneration) || invite.issuerMembershipGeneration < 0) {
      fail('permission-denied', 'Invitation is unavailable.');
    }
    const issuer = await owner(tx, invite.ownerUid);
    if (issuer.cafeId !== invite.cafeId || issuer.generation !== invite.issuerMembershipGeneration) {
      fail('permission-denied', 'Invitation is unavailable.');
    }
    const mapPath = `user_cafe_memberships/${uid}`;
    const memberPath = `cafes/${invite.cafeId}/members/${uid}`;
    const mapping = await tx.get(mapPath); const member = await tx.get(memberPath);
    if (mapping || member) {
      if (allowRejoin === true && mapping?.status === 'inactive' && invite.bindingVersion === 1) {
        return applyStaffRejoin({tx, uid, invite, invitationId, mapping, destinationMember: member,
          time: toTimestamp(now()), deny: fail});
      }
      fail('already-exists', 'This account already has a membership.');
    }
    // Bound invitations must never turn into first-time joins if the tombstone
    // is missing, deleted, or belongs to a different identity.
    if (Object.hasOwn(invite, 'bindingVersion') || Object.hasOwn(invite, 'targetUid') ||
        Object.hasOwn(invite, 'targetGeneration')) fail('permission-denied', 'Invitation binding is invalid.');
    const timestamp = toTimestamp(now());
    const link = {uid, cafeId: invite.cafeId, status: 'active', schemaVersion: 1,
      createdAt: timestamp, updatedAt: timestamp};
    tx.create(mapPath, link); tx.create(memberPath, {...link, role: 'staff'});
    tx.update(path, {status: 'redeemed', redeemedAt: timestamp, redeemedBy: uid});
    return {joined: true, cafeId: invite.cafeId};
  });
}
// Receipt observation only. Does not recover delivery, issue secrets or resolve
// absent receipts: a previously dispatched transaction may still commit later.
async function reconcileStaffInvitation({auth, data, store, now = () => new Date()}) {
  const uid = actor(auth);
  if (auth.token?.email_verified !== true) fail('unauthenticated', 'Verified identity required.');
  const {episode, payload} = mutationEpisode(data, InvitationError);
  input(payload, ['requestId']);
  const request = requestId(payload.requestId);
  return store.runTransaction(async tx => {
    const authority = await owner(tx, uid);
    expectedOwner(episode, authority);
    const receipt = await tx.get(`workspace_invite_requests/${hash(`${uid}\0${request}`)}`);
    if (receipt === null || receipt === undefined) return {state: 'unknown'};
    if (receipt.uid !== uid || receipt.cafeId !== authority.cafeId) {
      fail('permission-denied', 'Invitation observation unavailable.');
    }
    const validTime = value => Number.isFinite(millis(value));
    if (!/^[a-f0-9]{32}$/.test(receipt.invitationId ?? '') || !validTime(receipt.createdAt)) {
      fail('unavailable', 'Invitation observation unavailable.');
    }
    const invite = await tx.get(`workspace_invitations/${receipt.invitationId}`);
    if (!invite || invite.schemaVersion !== 1 || invite.ownerUid !== uid ||
        invite.cafeId !== authority.cafeId || invite.role !== 'staff' ||
        invite.issuerBindingVersion !== 1 || !Number.isSafeInteger(invite.issuerMembershipGeneration) ||
        invite.issuerMembershipGeneration < 0 || invite.issuerMembershipGeneration !== authority.generation ||
        typeof invite.tokenHash !== 'string' || !/^[a-f0-9]{64}$/.test(invite.tokenHash) ||
        typeof invite.email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(invite.email) ||
        !validTime(invite.createdAt) || millis(invite.createdAt) !== millis(receipt.createdAt) ||
        !validTime(invite.expiresAt) || millis(invite.expiresAt) <= millis(invite.createdAt) ||
        !['pending', 'revoked', 'redeemed'].includes(invite.status)) {
      fail('unavailable', 'Invitation observation unavailable.');
    }
    if ((invite.status === 'revoked' && (!validTime(invite.revokedAt) || invite.revokedBy !== uid)) ||
        (invite.status === 'redeemed' && (!validTime(invite.redeemedAt) || !id(invite.redeemedBy)))) {
      fail('unavailable', 'Invitation observation unavailable.');
    }
    const time = millis(now());
    if (!Number.isFinite(time)) fail('unavailable', 'Invitation observation unavailable.');
    return {state: 'committed', invitationState:
      invite.status === 'pending' && millis(invite.expiresAt) <= time ? 'expired' : invite.status};
  });
}
module.exports = {InvitationError, createStaffInvitation, revokeStaffInvitation, redeemStaffInvitation, reconcileStaffInvitation};
