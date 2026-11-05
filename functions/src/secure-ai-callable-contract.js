'use strict';
const MAX_RESPONSE_BYTES = 65536;
const NAMES = Object.freeze({issue: 'issueWorkspaceAiTicket', generate: 'generateWorkspaceAiRecipes'});
const DEFAULT_REASONS = Object.freeze({
  unauthenticated: 'sign-in-required', 'permission-denied': 'access-denied', aborted: 'workspace-changed',
  'invalid-argument': 'invalid-request', 'resource-exhausted': 'quota-exhausted',
  'failed-precondition': 'service-unavailable', 'already-exists': 'ticket-replayed',
  unavailable: 'service-unavailable', 'deadline-exceeded': 'provider-timeout',
  internal: 'service-unavailable', 'data-loss': 'invalid-response',
});
const REASONS = Object.freeze({
  ...Object.fromEntries(Object.entries(DEFAULT_REASONS).map(([code, reason]) => [code, [reason]])),
  unauthenticated: ['sign-in-required', 'email-unverified', 'account-disabled'],
  'resource-exhausted': ['quota-exhausted', 'workspace-busy', 'inventory-capacity', 'invalid-response'],
  'failed-precondition': ['service-unavailable', 'ticket-expired'],
  unavailable: ['service-unavailable', 'outcome-unknown'],
});
function safeReason(code, reason) { return REASONS[code]?.includes(reason) ? reason : DEFAULT_REASONS[code]; }
function jsonBytes(data) {
  const visit = value => {
    if (value === null || typeof value === 'boolean') return;
    if (typeof value === 'string') { if (!value.isWellFormed()) throw Error('Invalid JSON'); return; }
    if (typeof value === 'number' && Number.isFinite(value)) return;
    if (Array.isArray(value)) { for (const entry of value) visit(entry); return; }
    if (value && Object.getPrototypeOf(value) === Object.prototype) {
      for (const [key, entry] of Object.entries(value)) { visit(key); visit(entry); } return;
    }
    throw Error('Invalid JSON');
  };
  visit(data); return Buffer.byteLength(JSON.stringify(data), 'utf8');
}
function assertResponseBytes(data) {
  if (jsonBytes(data) > MAX_RESPONSE_BYTES) throw Error('Invalid response size');
  return data;
}
module.exports = {MAX_RESPONSE_BYTES, NAMES, DEFAULT_REASONS, safeReason, assertResponseBytes};
