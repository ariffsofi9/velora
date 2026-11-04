'use strict';

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
  if (cafe?.ownerUid !== uid || cafe.status !== 'active' || cafe.schemaVersion !== 1 ||
      !active(member, uid, cafeId) || member.role !== 'owner') {
    fail('permission-denied', 'Verified workspace owner required.');
  }
  return cafeId;
}
function requestId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{16,64}$/.test(value)) {
    fail('invalid-argument', 'Invalid invitation request ID.');
  }
  return value;
}
const millis = (value) => value instanceof Date ? value.getTime() : value?.toMillis?.();

async function createStaffInvitation({auth, data, store, now = () => new Date(),
  toTimestamp = (d) => d, random = randomBytes}) {
  const uid = actor(auth); input(data, ['email', 'requestId']);
  const targetEmail = email(data.email); const request = requestId(data.requestId);
  const invitationId = random(16).toString('hex');
  const secret = random(32).toString('hex');
  const code = `${invitationId}.${secret}`;
  const time = now(); const expires = new Date(time.getTime() + 24 * 60 * 60 * 1000);
  await store.runTransaction(async (tx) => {
    const cafeId = await owner(tx, uid);
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
      tokenHash: hash(code), status: 'pending', schemaVersion: 1,
      createdAt: toTimestamp(time), expiresAt: toTimestamp(expires)});
    tx.create(receipt, {uid, cafeId, invitationId, createdAt: toTimestamp(time)});
    const counter = {count: (rate?.count ?? 0) + 1, updatedAt: toTimestamp(time)};
    if (rate) tx.update(ratePath, counter); else tx.create(ratePath, counter);
  });
  return {invitationId, code, expiresAt: expires.toISOString()};
}
async function revokeStaffInvitation({auth, data, store, now = () => new Date(), toTimestamp = (d) => d}) {
  const uid = actor(auth); input(data, ['invitationId']);
  if (!/^[a-f0-9]{32}$/.test(data.invitationId ?? '')) fail('invalid-argument', 'Invalid invitation ID.');
  await store.runTransaction(async (tx) => {
    const cafeId = await owner(tx, uid);
    const path = `workspace_invitations/${data.invitationId}`;
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
async function redeemStaffInvitation({auth, data, store, now = () => new Date(), toTimestamp = (d) => d}) {
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
    if (await owner(tx, invite.ownerUid) !== invite.cafeId) fail('permission-denied', 'Invitation is unavailable.');
    const mapPath = `user_cafe_memberships/${uid}`;
    const memberPath = `cafes/${invite.cafeId}/members/${uid}`;
    const mapping = await tx.get(mapPath); const member = await tx.get(memberPath);
    if (mapping || member) fail('already-exists', 'This account already has a membership.');
    const timestamp = toTimestamp(now());
    const link = {uid, cafeId: invite.cafeId, status: 'active', schemaVersion: 1,
      createdAt: timestamp, updatedAt: timestamp};
    tx.create(mapPath, link); tx.create(memberPath, {...link, role: 'staff'});
    tx.update(path, {status: 'redeemed', redeemedAt: timestamp, redeemedBy: uid});
    return {joined: true, cafeId: invite.cafeId};
  });
}
module.exports = {InvitationError, createStaffInvitation, revokeStaffInvitation, redeemStaffInvitation};
