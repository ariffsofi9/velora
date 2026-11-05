'use strict';
const {HttpsError} = require('firebase-functions/v2/https');
const {SecureGroqError} = require('./secure-groq-handler');
const {AiQuotaError} = require('./ai-quota');
const {NAMES, DEFAULT_REASONS, safeReason, assertResponseBytes} = require('./secure-ai-callable-contract');

function createSecureAiCallableAdapters({handler}) {
  if (typeof handler !== 'function') throw Error('Handler dependency required.');
  const wrap = operation => async request => {
    try {
      if (request?.data?.operation !== operation) {
        throw new SecureGroqError('invalid-argument', 'invalid-request');
      }
      const result = await handler(request);
      try {
        assertResponseBytes(result);
        const fields = operation === 'issue' ? ['schemaVersion', 'ticketId', 'expiresAt']
          : ['schemaVersion', 'provider', 'ticketId', 'status', 'recipes', 'inventorySelection'];
        if (!result || Array.isArray(result) || Object.keys(result).length !== fields.length ||
            !fields.every(key => Object.hasOwn(result, key)) || result.schemaVersion !== 2 ||
            typeof result.ticketId !== 'string' || result.ticketId.length !== 64 || !/^[a-f0-9]{64}$/.test(result.ticketId) ||
            (operation === 'issue' && (!Number.isSafeInteger(result.expiresAt) || result.expiresAt <= 0)) ||
            (operation === 'generate' && (result.provider !== 'groq' || !Array.isArray(result.recipes) ||
              !['ok', 'no_suggestions'].includes(result.status)))) throw Error();
      } catch (_) { throw new SecureGroqError('data-loss', 'invalid-response'); }
      return result; // onCall supplies the wire envelope; never double-wrap {data/result}.
    } catch (error) {
      const known = error instanceof SecureGroqError || error instanceof AiQuotaError;
      const code = known && Object.hasOwn(DEFAULT_REASONS, error.code) ? error.code : 'internal';
      throw new HttpsError(code, 'AI suggestions are unavailable.', {
        reason: safeReason(code, known ? error.reason : undefined),
      });
    }
  };
  return Object.freeze({[NAMES.issue]: wrap('issue'), [NAMES.generate]: wrap('generate')});
}
module.exports = {createSecureAiCallableAdapters, NAMES};
