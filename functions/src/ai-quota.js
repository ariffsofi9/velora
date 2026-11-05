'use strict';

const {randomBytes} = require('node:crypto');
const {activeMembershipGeneration} = require('./membership-generation');
const {mutationEpisode, assertMutationEpisode} = require('./mutation-episode');
const DAY = 86400000;
const TICKET_MS = 300000;
const LEASE_MS = 120000;
const RETAIN_MS = 7 * DAY;
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  !/[\\/\p{Cc}]/u.test(value) && value.trim() === value && !['.', '..'].includes(value);
const nonce = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
class AiQuotaError extends Error {
  constructor(code, reason) { super('AI request cannot proceed.'); this.code = code; this.reason = reason; }
}
const fail = (code, reason) => { throw new AiQuotaError(code, reason); };
const active = (doc, uid, cafeId) => doc && doc.uid === uid && doc.cafeId === cafeId &&
  doc.status === 'active' && doc.schemaVersion === 1;
const userPath = uid => `ai_usage_users/${uid}`;
const workspacePath = cafeId => `ai_usage_workspaces/${cafeId}`;
const ticketPath = key => `ai_generation_tickets/${key}`;
const receiptPath = key => `ai_generation_requests/${key}`;

async function authority(tx, auth, expected) {
  if (!id(auth?.uid)) fail('unauthenticated');
  if (auth.token?.email_verified !== true) fail('failed-precondition');
  const {episode, payload} = mutationEpisode(expected, AiQuotaError);
  if (Object.keys(payload).length) fail('invalid-argument');
  const uid = auth.uid;
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping?.cafeId;
  if (!id(cafeId) || !active(mapping, uid, cafeId)) fail('permission-denied');
  const cafe = await tx.get(`cafes/${cafeId}`);
  const ownerUid = cafe?.ownerUid;
  if (!id(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) fail('permission-denied');
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const ownerMap = ownerUid === uid ? mapping : await tx.get(`user_cafe_memberships/${ownerUid}`);
  const ownerMember = ownerUid === uid ? member : await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const generation = activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid);
  const ownerGeneration = activeMembershipGeneration(ownerMap, ownerMember, ownerUid, cafeId, ownerUid);
  if (generation === null || ownerGeneration === null) fail('permission-denied');
  assertMutationEpisode(episode, cafeId, generation, AiQuotaError);
  return {uid, cafeId, generation, ownerUid, ownerGeneration};
}

function usage(doc, day, subject) {
  if (!doc) return {schemaVersion: 1, subject, day, admitted: 0, issued: 0, lock: null};
  if (doc.schemaVersion !== 1 || doc.subject !== subject || !integer(doc.day) ||
      !integer(doc.admitted) || !integer(doc.issued) || !Object.hasOwn(doc, 'lock')) fail('failed-precondition');
  if (doc.day > day) fail('failed-precondition');
  if (doc.lock !== null && (!nonce(doc.lock?.ticketId) || !nonce(doc.lock?.fence) ||
      !integer(doc.lock?.until))) fail('failed-precondition');
  return {...doc, day, admitted: doc.day === day ? doc.admitted : 0,
    issued: doc.day === day ? doc.issued : 0};
}
function validTicket(ticket, key) {
  if (!ticket || ticket.schemaVersion !== 1 || ticket.ticketId !== key ||
      !id(ticket.uid) || !id(ticket.cafeId) || !id(ticket.ownerUid) ||
      !integer(ticket.generation) || !integer(ticket.ownerGeneration) ||
      !integer(ticket.issuedAt) || (Object.hasOwn(ticket, 'payloadDigest') && !nonce(ticket.payloadDigest)) ||
      ticket.expiresAt !== ticket.issuedAt + TICKET_MS ||
      ticket.retainUntil !== ticket.expiresAt + RETAIN_MS ||
      !['issued', 'admitted', 'dispatched', 'quarantined', 'completed', 'abandoned'].includes(ticket.state)) {
    fail('failed-precondition');
  }
}
function sameAuthority(ticket, current) {
  if (['uid', 'cafeId', 'generation', 'ownerUid', 'ownerGeneration'].some(k => ticket[k] !== current[k])) {
    fail('permission-denied');
  }
}
function validReceipt(receipt, ticket, key) {
  if (!receipt || receipt.schemaVersion !== 1 || receipt.ticketId !== key ||
      receipt.uid !== ticket.uid || receipt.cafeId !== ticket.cafeId ||
      !nonce(receipt.fence) || !integer(receipt.admittedAt) ||
      receipt.leaseUntil !== receipt.admittedAt + LEASE_MS ||
      receipt.retainUntil !== receipt.admittedAt + RETAIN_MS || receipt.state !== ticket.state) {
    fail('failed-precondition');
  }
}

/** Adapter for an already-created Admin Firestore instance. No initialization or I/O on import. */
function adminQuotaStore(db) {
  return {runTransaction: operation => db.runTransaction(native => operation({
    get: async path => { const snap = await native.get(db.doc(path)); return snap.exists ? snap.data() : null; },
    create: (path, data) => native.create(db.doc(path), data),
    update: (path, data) => native.update(db.doc(path), data),
    delete: path => native.delete(db.doc(path)),
    inventory: async (cafeId, limit) => {
      const snapshot = await native.get(db.collection(`cafes/${cafeId}/inventory`).limit(limit));
      return snapshot.docs.map(doc => ({id: doc.id, data: doc.data()}));
    },
  }))};
}

// Trusted backend library only. No provider, callable, credentials, timers or network access.
function createAiQuota({store, now = Date.now, random = () => randomBytes(32).toString('hex'),
  requirePayloadDigest = false}) {
  const transaction = async operation => {
    try { return await store.runTransaction(operation); }
    catch (error) {
      if (error instanceof AiQuotaError) throw error;
      // Storage/SDK errors may contain document data; never expose their text.
      fail('unavailable');
    }
  };
  const clock = () => {
    const time = now();
    if (!integer(time) || time > Number.MAX_SAFE_INTEGER - RETAIN_MS - TICKET_MS) fail('failed-precondition');
    return time;
  };
  const fresh = () => { const value = random(); if (!nonce(value)) fail('failed-precondition'); return value; };
  const writeUsage = (tx, path, previous, next) => previous ? tx.update(path, next) : tx.create(path, next);
  const checkDigest = (ticket, digest) => {
    if (requirePayloadDigest || Object.hasOwn(ticket, 'payloadDigest') || digest !== undefined) {
      if (!nonce(digest) || !nonce(ticket.payloadDigest) || digest !== ticket.payloadDigest) fail('failed-precondition');
    }
  };

  async function issue({auth, expected, payloadDigest}) {
    if ((requirePayloadDigest || payloadDigest !== undefined) && !nonce(payloadDigest)) fail('invalid-argument');
    // Generated once outside retryable callback; native create rejects collisions.
    const ticketId = fresh();
    return transaction(async tx => {
      const current = await authority(tx, auth, expected);
      const time = clock(); const day = Math.floor(time / DAY);
      const up = userPath(current.uid); const wp = workspacePath(current.cafeId);
      const previousUser = await tx.get(up); const previousWorkspace = await tx.get(wp);
      const user = usage(previousUser, day, current.uid);
      const workspace = usage(previousWorkspace, day, current.cafeId);
      // Issuance budget is separate from admitted quota: 2x the daily allowance.
      if (workspace.lock) fail('resource-exhausted', 'workspace-busy');
      if (user.issued >= 20 || workspace.issued >= 60 || user.admitted >= 10 ||
          workspace.admitted >= 30) fail('resource-exhausted', 'quota-exhausted');
      const ticket = {schemaVersion: 1, ticketId, ...current, issuedAt: time,
        expiresAt: time + TICKET_MS, retainUntil: time + TICKET_MS + RETAIN_MS, state: 'issued',
        ...(payloadDigest === undefined ? {} : {payloadDigest})};
      writeUsage(tx, up, previousUser, {...user, issued: user.issued + 1});
      writeUsage(tx, wp, previousWorkspace, {...workspace, issued: workspace.issued + 1});
      tx.create(ticketPath(ticketId), ticket);
      return {ticketId, expiresAt: ticket.expiresAt};
    });
  }

  async function admit({auth, expected, ticketId, payloadDigest}) {
    if (!nonce(ticketId)) fail('invalid-argument');
    const fence = fresh();
    return transaction(async tx => {
      const current = await authority(tx, auth, expected);
      const time = clock(); const day = Math.floor(time / DAY);
      const ticket = await tx.get(ticketPath(ticketId));
      validTicket(ticket, ticketId); sameAuthority(ticket, current); checkDigest(ticket, payloadDigest);
      const receipt = await tx.get(receiptPath(ticketId));
      if (ticket.state !== 'issued') {
        validReceipt(receipt, ticket, ticketId);
        // Replay never returns a dispatch capability or charges again.
        return {ticketId, admitted: false, state: ticket.state};
      }
      if (time >= ticket.expiresAt) fail('failed-precondition', 'ticket-expired');
      if (receipt || time < ticket.issuedAt) fail('failed-precondition');
      const up = userPath(current.uid); const wp = workspacePath(current.cafeId);
      const oldUser = await tx.get(up); const oldWorkspace = await tx.get(wp);
      if (!oldUser || !oldWorkspace) fail('failed-precondition');
      const user = usage(oldUser, day, current.uid); const workspace = usage(oldWorkspace, day, current.cafeId);
      if (workspace.lock) fail('resource-exhausted', 'workspace-busy');
      if (user.admitted >= 10 || workspace.admitted >= 30) fail('resource-exhausted', 'quota-exhausted');
      const leaseUntil = time + LEASE_MS;
      tx.update(up, {...user, admitted: user.admitted + 1});
      tx.update(wp, {...workspace, admitted: workspace.admitted + 1, lock: {ticketId, fence, until: leaseUntil}});
      tx.update(ticketPath(ticketId), {state: 'admitted'});
      tx.create(receiptPath(ticketId), {schemaVersion: 1, ticketId, uid: current.uid,
        cafeId: current.cafeId, state: 'admitted', fence, admittedAt: time,
        leaseUntil, retainUntil: time + RETAIN_MS});
      return {ticketId, admitted: true, fence};
    });
  }

  async function transition({ticketId, fence, action, auth, expected, outcome, payloadDigest}) {
    if (!nonce(ticketId) || !nonce(fence)) fail('invalid-argument');
    if (action === 'complete' && !['success', 'provider-rejected', 'unknown', 'timeout'].includes(outcome)) {
      fail('invalid-argument');
    }
    return transaction(async tx => {
      const ticket = await tx.get(ticketPath(ticketId)); validTicket(ticket, ticketId);
      if (action === 'dispatch') {
        sameAuthority(ticket, await authority(tx, auth, expected)); checkDigest(ticket, payloadDigest);
      }
      const receipt = await tx.get(receiptPath(ticketId)); validReceipt(receipt, ticket, ticketId);
      const wp = workspacePath(ticket.cafeId); const old = await tx.get(wp);
      const time = clock(); const workspace = usage(old, Math.floor(time / DAY), ticket.cafeId);
      const lock = workspace.lock;
      if (!old || receipt.fence !== fence || lock?.fence !== fence || lock?.ticketId !== ticketId ||
          lock.until !== receipt.leaseUntil || !['admitted', 'dispatched'].includes(ticket.state) ||
          time < receipt.admittedAt) fail('failed-precondition');
      let state;
      if (action === 'dispatch') {
        if (ticket.state !== 'admitted' || time >= lock.until) fail('failed-precondition');
        state = 'dispatched';
      } else if (action === 'recover') {
        if (time < lock.until) fail('failed-precondition');
        state = ticket.state === 'admitted' ? 'abandoned' : 'quarantined';
      } else {
        if (ticket.state !== 'dispatched') fail('failed-precondition');
        state = ['unknown', 'timeout'].includes(outcome) || time >= lock.until ? 'quarantined' : 'completed';
      }
      tx.update(ticketPath(ticketId), {state});
      tx.update(receiptPath(ticketId), {state, updatedAt: time,
        ...(action === 'complete' ? {outcome} : {})});
      tx.update(wp, {...workspace, lock: ['completed', 'abandoned'].includes(state) ? null : lock});
      return {ticketId, state, dispatch: action === 'dispatch'};
    });
  }
  // Trusted maintenance only: bounded candidate IDs, never caller timestamps or
  // a collection sweep. Each ticket/receipt pair is deleted in one transaction.
  async function cleanupExpired({ticketIds}) {
    if (!Array.isArray(ticketIds) || ticketIds.length < 1 || ticketIds.length > 10 ||
        ticketIds.some(key => !nonce(key)) || new Set(ticketIds).size !== ticketIds.length) {
      fail('invalid-argument');
    }
    const results = [];
    for (const key of ticketIds) {
      results.push(await transaction(async tx => {
        const ticket = await tx.get(ticketPath(key));
        const receipt = await tx.get(receiptPath(key));
        // Missing/orphan records never become new admissions or get guessed at.
        if (!ticket) return {ticketId: key, state: receipt ? 'orphan-preserved' : 'missing'};
        validTicket(ticket, key);
        const time = clock();
        if (!['issued', 'completed', 'abandoned'].includes(ticket.state)) {
          return {ticketId: key, state: 'protected'};
        }
        if (time < ticket.retainUntil) return {ticketId: key, state: 'retained'};
        if (ticket.state === 'issued') {
          if (receipt) fail('failed-precondition');
        } else {
          validReceipt(receipt, ticket, key);
          if (time < receipt.retainUntil) return {ticketId: key, state: 'retained'};
        }
        const existing = await tx.get(workspacePath(ticket.cafeId));
        if (!existing) fail('failed-precondition');
        const workspace = usage(existing, Math.floor(time / DAY), ticket.cafeId);
        if (workspace.lock?.ticketId === key) return {ticketId: key, state: 'protected'};
        // Do not persist the normalized counters or alter another request's lock.
        tx.delete(ticketPath(key));
        if (receipt) tx.delete(receiptPath(key));
        return {ticketId: key, state: 'deleted'};
      }));
    }
    return results;
  }
  // Trusted read-only callback, executed within the same authority transaction.
  async function inspectTicket({auth, expected, ticketId, payloadDigest, read}) {
    if (!nonce(ticketId) || typeof read !== 'function') fail('invalid-argument');
    return transaction(async tx => {
      const current = await authority(tx, auth, expected);
      const ticket = await tx.get(ticketPath(ticketId));
      validTicket(ticket, ticketId); sameAuthority(ticket, current); checkDigest(ticket, payloadDigest);
      return read(tx, current);
    });
  }
  return {issue, admit, cleanupExpired, inspectTicket,
    dispatch: input => transition({...input, action: 'dispatch'}),
    complete: input => transition({...input, action: 'complete'}),
    recoverExpired: input => transition({...input, action: 'recover'})};
}
module.exports = {createAiQuota, adminQuotaStore, AiQuotaError};
