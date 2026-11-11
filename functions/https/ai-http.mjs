import groq from '../src/secure-groq-handler.js';
import quotaDomain from '../src/ai-quota.js';
import {bounded, requireTestProject, validBudget} from '../backend/backend-errors.mjs';
import {createAuthenticatedJsonHttp, DOMAIN_HTTP_STATUSES} from './authenticated-json-http.mjs';

// Unwired TEST-only boundary. Provider/secret dependencies have no live defaults.
// The canonical handler owns digest, admission, fencing and output validation.
export function createAiHttp({projectId, storeProjectId, verifyIdentity, store,
  getAccount, transport, getSecret, now = Date.now, timeoutMs = 15000,
  accountTimeoutMs = 5000, verificationTimeoutMs = 5000, bodyTimeoutMs = 5000,
  cleanupTimeoutMs = 100, scheduleTimeout} = {}) {
  requireTestProject(projectId);
  if (typeof store?.runTransaction !== 'function' || store.projectId !== projectId ||
      typeof getAccount !== 'function' || getAccount.projectId !== projectId ||
      typeof transport !== 'function' || typeof getSecret !== 'function' ||
      typeof now !== 'function' || !validBudget(accountTimeoutMs)) {
    throw Error('Explicit AI dependencies required');
  }
  const quota = quotaDomain.createAiQuota({store, now, requirePayloadDigest: true});
  const handler = groq.createSecureGroqHandler({store, quota, now, transport, getSecret, timeoutMs,
    getAccount: uid => bounded(() => getAccount(uid), accountTimeoutMs, 'account')});
  return createAuthenticatedJsonHttp({projectId, storeProjectId, verifyIdentity,
    verificationTimeoutMs, bodyTimeoutMs, cleanupTimeoutMs,
    ...(scheduleTimeout === undefined ? {} : {scheduleTimeout}),
    domainErrorTypes: [groq.SecureGroqError], domainStatuses: {...DOMAIN_HTTP_STATUSES, aborted: 409},
    routes: new Map(['issue', 'generate'].map(operation => [`/ai/${operation}`, ({auth, data}) => {
      // Operation comes exclusively from the route; even an identical client
      // selector is rejected instead of silently overriding a privileged field.
      if (Object.hasOwn(data, 'operation')) throw new groq.SecureGroqError('invalid-argument');
      return handler({auth, data: {...data, operation}});
    }]))});
}
